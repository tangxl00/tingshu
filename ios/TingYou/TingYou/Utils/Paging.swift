import Foundation

struct Paging {
    let page: Int
    let pageSize: Int
    var nextPage: Int { page + 1 }
}
